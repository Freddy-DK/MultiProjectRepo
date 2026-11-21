codeunit 90061 "HelloWorld Test Licensing"
{
    Subtype = Test;

    [Test]
    procedure TestHelloWorldMessage()
    var
        CustList: TestPage "Customer List";
    begin
        CustList.OpenView();
        CustList.Close();
    end;
}

